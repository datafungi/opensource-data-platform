CREATE SCHEMA IF NOT EXISTS finops;

CREATE TABLE finops.cloud_resources (
    resource_id          INTEGER        NOT NULL,
    resource_name        VARCHAR(200)   NOT NULL,
    provider             VARCHAR(20)    NOT NULL,
    service_type         VARCHAR(50)    NOT NULL,
    region               VARCHAR(50)    NOT NULL,
    environment          VARCHAR(20)    NOT NULL,
    department_id        VARCHAR(20)    NOT NULL,
    cost_center          VARCHAR(20)    NOT NULL,
    monthly_base_cost    NUMERIC(10, 2) NOT NULL,
    CONSTRAINT pk_cloud_resources PRIMARY KEY (resource_id),
    CONSTRAINT chk_provider CHECK (provider IN ('AWS', 'Azure', 'GCP')),
    CONSTRAINT chk_environment CHECK (environment IN ('prod', 'staging', 'dev')),
    CONSTRAINT fk_resources_dept FOREIGN KEY (department_id)
        REFERENCES human_resource.departments (department_id)
);

CREATE TABLE finops.daily_billing (
    billing_id           INTEGER        NOT NULL,
    resource_id          INTEGER        NOT NULL,
    project_id           INTEGER,
    billing_date         DATE           NOT NULL,
    usage_quantity       NUMERIC(12, 4) NOT NULL,
    usage_unit           VARCHAR(30)    NOT NULL,
    unit_cost            NUMERIC(10, 6) NOT NULL,
    discount_pct         NUMERIC(5, 2)  NOT NULL DEFAULT 0,
    daily_cost           NUMERIC(10, 2) NOT NULL,
    CONSTRAINT pk_daily_billing PRIMARY KEY (billing_id),
    CONSTRAINT chk_discount CHECK (discount_pct >= 0 AND discount_pct <= 100),
    CONSTRAINT fk_billing_resource FOREIGN KEY (resource_id)
        REFERENCES finops.cloud_resources (resource_id),
    CONSTRAINT fk_billing_project FOREIGN KEY (project_id)
        REFERENCES operations.projects (project_id)
);

CREATE TABLE finops.incident_types (
    incident_type_code   VARCHAR(20)    NOT NULL,
    name                 VARCHAR(100)   NOT NULL,
    description          VARCHAR(500)   NOT NULL,
    typical_causes       VARCHAR(500)   NOT NULL,
    impacted_services    VARCHAR(200)   NOT NULL,
    is_customer_facing   BOOLEAN        NOT NULL DEFAULT TRUE,
    avg_p1_pct           NUMERIC(5, 2)  NOT NULL,
    avg_p2_pct           NUMERIC(5, 2)  NOT NULL,
    CONSTRAINT pk_incident_types PRIMARY KEY (incident_type_code)
);

CREATE TABLE finops.engineering_incidents (
    incident_id              INTEGER        NOT NULL,
    resource_id              INTEGER        NOT NULL,
    project_id               INTEGER,
    incident_type_code       VARCHAR(20)    NOT NULL,
    severity                 VARCHAR(2)     NOT NULL,
    started_at               TIMESTAMP      NOT NULL,
    resolved_at              TIMESTAMP      NOT NULL,
    time_to_resolve_hours    NUMERIC(8, 2)  NOT NULL,
    department_id            VARCHAR(20)    NOT NULL,
    CONSTRAINT pk_incidents PRIMARY KEY (incident_id),
    CONSTRAINT chk_severity CHECK (severity IN ('P1', 'P2', 'P3', 'P4')),
    CONSTRAINT fk_incident_type FOREIGN KEY (incident_type_code)
        REFERENCES finops.incident_types (incident_type_code),
    CONSTRAINT fk_incident_resource FOREIGN KEY (resource_id)
        REFERENCES finops.cloud_resources (resource_id),
    CONSTRAINT fk_incident_project FOREIGN KEY (project_id)
        REFERENCES operations.projects (project_id),
    CONSTRAINT fk_incident_dept FOREIGN KEY (department_id)
        REFERENCES human_resource.departments (department_id)
);
