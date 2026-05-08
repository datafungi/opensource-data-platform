# =============================================================================
# oss-data-platform — Spark image
#
# Stack integration:
#   Apache Iceberg  — open table format (REST catalog via Polaris)
#   SeaweedFS       — S3-compatible object store  (s3a://)
#   Redpanda        — Kafka-compatible broker for Structured Streaming
#   Debezium CDC    — events land in Redpanda topics (Avro or JSON)
#   ClickHouse      — real-time analytics sink
#
# Key dependency changes vs. older Spark images:
#   • Spark 4.x requires Scala 2.13 — all artifact coordinates use _2.13
#   • Spark 4.x requires Java 17+ — Java 11/8 no longer supported
#   • hadoop-aws 3.4.x migrated from AWS SDK v1 to v2 — the required bundle
#     is now software.amazon.awssdk:bundle, NOT com.amazonaws:aws-java-sdk-bundle
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — JAR resolver
# Fetches all connector JARs from Maven Central at build time so the
# runtime container needs no outbound internet access.
# -----------------------------------------------------------------------------
FROM curlimages/curl:8.13.0 AS jars

ARG ICEBERG_VERSION=1.10.1
ARG SPARK_COMPAT=4.0
ARG SCALA_VERSION=2.13
ARG SPARK_VERSION=4.1.1
ARG HADOOP_AWS_VERSION=3.4.2
ARG AWS_SDK_V2_VERSION=2.29.52
ARG KAFKA_VERSION=3.9.1
ARG COMMONS_POOL2_VERSION=2.12.0
ARG CLICKHOUSE_SPARK_VERSION=0.10.0

WORKDIR /jars

RUN set -eux; \
    MAVEN="https://repo1.maven.org/maven2"; \
    \
    # Iceberg: shaded runtime fat JAR (all catalog/IO libs included)
    curl -fsSL "${MAVEN}/org/apache/iceberg/iceberg-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}-${ICEBERG_VERSION}.jar" \
         -o iceberg-spark-runtime.jar; \
    \
    # S3A — SeaweedFS (s3a://)
    # hadoop-aws 3.4.x dropped AWS SDK v1; the required dependency is now the v2 bundle
    curl -fsSL "${MAVEN}/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
         -o hadoop-aws.jar; \
    curl -fsSL "${MAVEN}/software/amazon/awssdk/bundle/${AWS_SDK_V2_VERSION}/bundle-${AWS_SDK_V2_VERSION}.jar" \
         -o aws-sdk-bundle-v2.jar; \
    \
    # Kafka Structured Streaming — Redpanda is Kafka-protocol compatible
    # spark-sql-kafka is not a fat JAR; its runtime deps must be shipped alongside it
    curl -fsSL "${MAVEN}/org/apache/spark/spark-sql-kafka-0-10_${SCALA_VERSION}/${SPARK_VERSION}/spark-sql-kafka-0-10_${SCALA_VERSION}-${SPARK_VERSION}.jar" \
         -o spark-sql-kafka.jar; \
    curl -fsSL "${MAVEN}/org/apache/spark/spark-token-provider-kafka-0-10_${SCALA_VERSION}/${SPARK_VERSION}/spark-token-provider-kafka-0-10_${SCALA_VERSION}-${SPARK_VERSION}.jar" \
         -o spark-token-provider-kafka.jar; \
    curl -fsSL "${MAVEN}/org/apache/kafka/kafka-clients/${KAFKA_VERSION}/kafka-clients-${KAFKA_VERSION}.jar" \
         -o kafka-clients.jar; \
    curl -fsSL "${MAVEN}/org/apache/commons/commons-pool2/${COMMONS_POOL2_VERSION}/commons-pool2-${COMMONS_POOL2_VERSION}.jar" \
         -o commons-pool2.jar; \
    \
    # Avro support — Debezium CDC events are typically Avro-encoded
    curl -fsSL "${MAVEN}/org/apache/spark/spark-avro_${SCALA_VERSION}/${SPARK_VERSION}/spark-avro_${SCALA_VERSION}-${SPARK_VERSION}.jar" \
         -o spark-avro.jar; \
    \
    # ClickHouse connector: shaded fat JAR, built against Spark 4.0 API (compatible with 4.1)
    curl -fsSL "${MAVEN}/com/clickhouse/spark/clickhouse-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}/${CLICKHOUSE_SPARK_VERSION}/clickhouse-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}-${CLICKHOUSE_SPARK_VERSION}.jar" \
         -o clickhouse-spark-runtime.jar

# -----------------------------------------------------------------------------
# Stage 2 — Final image
# -----------------------------------------------------------------------------
FROM apache/spark:4.1.1

LABEL org.opencontainers.image.title="oss-data-platform/spark" \
      org.opencontainers.image.description="PySpark 4.1.1 · Iceberg 1.10.1 · SeaweedFS S3A · Redpanda/Kafka streaming · ClickHouse"

# Bring in uv — consistent with the Airflow image. Used here to install Python
# 3.12 and packages without touching apt or any PPA.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

USER root

# Install Python 3.12 via uv (python-build-standalone; no compilation).
# UV_PYTHON_INSTALL_DIR must be a system-wide path: uv's default (~/.local) is
# under root's home and would be unreachable by the spark executor user (UID 185).
# The symlink at /usr/local/bin/python3.12 gives PYSPARK_PYTHON a stable path
# that does not embed the CPython patch version.
ENV UV_PYTHON_INSTALL_DIR=/opt/python

# uv marks its managed Python installations as EXTERNALLY-MANAGED and refuses
# --system installs into them. A venv sidesteps the restriction cleanly.
RUN uv python install 3.12 \
    && uv venv --python 3.12 /opt/spark-venv

# With VIRTUAL_ENV set, uv targets the venv automatically in subsequent steps.
ENV VIRTUAL_ENV=/opt/spark-venv

# pyarrow: Arrow-based data transfer in PySpark 4.x (toPandas, mapInArrow, pandas UDFs).
# pandas: UDF authoring convenience.
RUN uv pip install --no-cache \
        pyarrow \
        pandas

ENV PYSPARK_PYTHON=/opt/spark-venv/bin/python3.12 \
    PYSPARK_DRIVER_PYTHON=/opt/spark-venv/bin/python3.12

# Pre-baked connector JARs — no internet access needed at runtime
COPY --from=jars /jars/*.jar /opt/spark/jars/

# Platform-level Spark defaults (non-sensitive structural settings)
# Credentials and endpoints are injected at runtime via environment variables
COPY conf/spark-defaults.conf /opt/spark/conf/spark-defaults.conf

# Restore the unprivileged Spark user (UID 185 in apache/spark base image)
USER 185
