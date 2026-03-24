ARG AIRFLOW_VERSION=3.1.7
ARG AIRFLOW_HOME=/opt/airflow
ARG PYTHON_VERSION=3.12
ARG CONSTRAINT_URL=https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt

FROM apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION} AS base

LABEL authors="Nguyen Vo"
LABEL maintainer="Nguyen Vo"

USER root

RUN apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
    git \
    make \
    nano \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

FROM base AS airflow

ARG AIRFLOW_HOME=/opt/airflow

USER 50000

WORKDIR ${AIRFLOW_HOME}

COPY pyproject.toml uv.lock ./

RUN uv pip install --upgrade pip && uv pip install -r pyproject.toml

ENV PYTHONDONTWRITEBYTECODE=1
