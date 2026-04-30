{{
  config(
    materialized = 'view',
    schema = 'staging'
  )
}}

-- Casts raw ingested orders to canonical types.
-- Source: orders table populated by etl_orders Airflow DAG.
SELECT
    toUInt64(order_id)               AS order_id,
    toString(customer_id)            AS customer_id,
    toDate(order_date)               AS order_date,
    toFloat64(amount)                AS amount_usd,
    lower(trim(toString(status)))    AS status,
    now()                            AS _loaded_at
FROM {{ source('raw', 'orders') }}
WHERE order_id IS NOT NULL
