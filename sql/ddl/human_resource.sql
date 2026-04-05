CREATE SCHEMA IF NOT EXISTS human_resource;

CREATE TABLE human_resource.locations
(
    id          INTEGER      NOT NULL,
    location_id VARCHAR(10)  NOT NULL,
    city        VARCHAR(100) NOT NULL,
    country     VARCHAR(100) NOT NULL,
    currency    CHAR(3)      NOT NULL,
    timezone    VARCHAR(50)  NOT NULL,
    CONSTRAINT pk_locations PRIMARY KEY (location_id)
);

CREATE TABLE human_resource.departments
(
    id              INTEGER      NOT NULL,
    department_id   VARCHAR(20)  NOT NULL,
    department_name VARCHAR(100) NOT NULL,
    cost_center     VARCHAR(20)  NOT NULL,
    CONSTRAINT pk_departments PRIMARY KEY (department_id)
);

CREATE TABLE human_resource.employees
(
    employee_id      INTEGER        NOT NULL,
    first_name       VARCHAR(100)   NOT NULL,
    last_name        VARCHAR(100)   NOT NULL,
    email            VARCHAR(200)   NOT NULL,
    job_title        VARCHAR(100)   NOT NULL,
    department_id    VARCHAR(20)    NOT NULL,
    location_id      VARCHAR(10)    NOT NULL,
    hire_date        DATE           NOT NULL,
    termination_date DATE,
    current_salary   NUMERIC(12, 2) NOT NULL,
    salary_currency  CHAR(3)        NOT NULL,
    is_active        BOOLEAN        NOT NULL DEFAULT TRUE,
    manager_id       INTEGER,
    CONSTRAINT pk_employees PRIMARY KEY (employee_id),
    CONSTRAINT fk_employees_department FOREIGN KEY (department_id)
        REFERENCES human_resource.departments (department_id),
    CONSTRAINT fk_employees_location FOREIGN KEY (location_id)
        REFERENCES human_resource.locations (location_id),
    CONSTRAINT fk_employees_manager FOREIGN KEY (manager_id)
        REFERENCES human_resource.employees (employee_id)
);

CREATE TABLE human_resource.employee_events
(
    event_id       VARCHAR(20) NOT NULL,
    employee_id    INTEGER     NOT NULL,
    event_type     VARCHAR(20) NOT NULL,
    effective_date DATE        NOT NULL,
    old_salary     NUMERIC(12, 2),
    new_salary     NUMERIC(12, 2),
    old_job_title  VARCHAR(100),
    new_job_title  VARCHAR(100),
    CONSTRAINT pk_employee_events PRIMARY KEY (event_id),
    CONSTRAINT fk_employee_events_employee FOREIGN KEY (employee_id)
        REFERENCES human_resource.employees (employee_id),
    CONSTRAINT chk_event_type CHECK (event_type IN ('Hire', 'Promotion', 'Termination'))
);
