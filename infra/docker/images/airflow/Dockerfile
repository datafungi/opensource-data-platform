ARG AIRFLOW_VERSION=3.2.0
ARG PYTHON_VERSION=3.12
ARG AIRFLOW_HOME=/opt/airflow

# ============================================================
# Stage 1: Python dependency builder
# ============================================================
FROM apache/airflow:slim-${AIRFLOW_VERSION}-python${PYTHON_VERSION} AS python-builder

ARG AIRFLOW_HOME=/opt/airflow

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 50000
WORKDIR ${AIRFLOW_HOME}

# Copy dependency files first for better layer caching —
# this layer is only invalidated when deps actually change
COPY --chown=50000:0 pyproject.toml uv.lock ./

RUN uv export --frozen --no-dev --no-hashes -o /tmp/requirements.txt \
    && uv pip install --no-cache -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# ============================================================
# Stage 2: Final lean runtime image
# ============================================================
FROM apache/airflow:slim-${AIRFLOW_VERSION}-python${PYTHON_VERSION} AS final

ARG AIRFLOW_HOME=/opt/airflow

LABEL authors="Nguyen Vo"
LABEL maintainer="Nguyen Vo"

# Copy installed Python packages from builder
COPY --from=python-builder /home/airflow/.local /home/airflow/.local

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 50000
WORKDIR ${AIRFLOW_HOME}
