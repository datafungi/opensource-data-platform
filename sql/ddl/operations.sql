CREATE SCHEMA IF NOT EXISTS operations;

CREATE TABLE operations.projects (
    project_id          INTEGER        NOT NULL,
    opportunity_id      INTEGER        NOT NULL,
    account_id          INTEGER        NOT NULL,
    name                VARCHAR(300)   NOT NULL,
    project_type        VARCHAR(100)   NOT NULL,
    billing_model       VARCHAR(50)    NOT NULL,
    budget              NUMERIC(14, 2),
    start_date          DATE           NOT NULL,
    end_date            DATE           NOT NULL,
    status              VARCHAR(20)    NOT NULL,
    project_manager_id  INTEGER,
    CONSTRAINT pk_projects PRIMARY KEY (project_id),
    CONSTRAINT chk_project_status CHECK (status IN ('Planning', 'Active', 'Completed')),
    CONSTRAINT fk_projects_manager FOREIGN KEY (project_manager_id)
        REFERENCES human_resource.employees (employee_id)
);

CREATE TABLE operations.resource_allocations (
    allocation_id   INTEGER  NOT NULL,
    project_id      INTEGER  NOT NULL,
    employee_id     INTEGER  NOT NULL,
    start_date      DATE     NOT NULL,
    end_date        DATE     NOT NULL,
    allocation_pct  INTEGER  NOT NULL,
    CONSTRAINT pk_allocations PRIMARY KEY (allocation_id),
    CONSTRAINT chk_allocation_pct CHECK (allocation_pct IN (50, 75, 100)),
    CONSTRAINT fk_alloc_project FOREIGN KEY (project_id)
        REFERENCES operations.projects (project_id),
    CONSTRAINT fk_alloc_employee FOREIGN KEY (employee_id)
        REFERENCES human_resource.employees (employee_id)
);

CREATE TABLE operations.timesheets (
    timesheet_id    INTEGER        NOT NULL,
    allocation_id   INTEGER        NOT NULL,
    project_id      INTEGER        NOT NULL,
    employee_id     INTEGER        NOT NULL,
    work_date       DATE           NOT NULL,
    hours           NUMERIC(4, 1)  NOT NULL,
    billable_hours  NUMERIC(4, 2)  NOT NULL,
    internal_hours  NUMERIC(4, 2)  NOT NULL,
    CONSTRAINT pk_timesheets PRIMARY KEY (timesheet_id),
    CONSTRAINT fk_ts_allocation FOREIGN KEY (allocation_id)
        REFERENCES operations.resource_allocations (allocation_id),
    CONSTRAINT fk_ts_project FOREIGN KEY (project_id)
        REFERENCES operations.projects (project_id),
    CONSTRAINT fk_ts_employee FOREIGN KEY (employee_id)
        REFERENCES human_resource.employees (employee_id)
);
