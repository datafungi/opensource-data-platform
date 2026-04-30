FROM bitnami/spark:4.1.1

# Spark 4.x uses Scala 2.13; Iceberg publishes a 4.0_2.13 runtime compatible with Spark 4.x
ARG ICEBERG_VERSION=1.10.1
ARG SPARK_COMPAT=4.0
ARG SCALA_VERSION=2.13
ARG HADOOP_AWS_VERSION=3.3.6
ARG AWS_SDK_VERSION=1.12.783

# Download Iceberg runtime and S3A/AWS SDK JARs for reading/writing:
#   - Apache Iceberg tables in SeaweedFS (s3a://)
#   - Polaris REST catalog integration
USER root
RUN curl -fsSL \
      "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}-${ICEBERG_VERSION}.jar" \
      -o /opt/bitnami/spark/jars/iceberg-spark-runtime.jar \
  && curl -fsSL \
      "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
      -o /opt/bitnami/spark/jars/hadoop-aws.jar \
  && curl -fsSL \
      "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VERSION}/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar" \
      -o /opt/bitnami/spark/jars/aws-java-sdk-bundle.jar

USER 1001
