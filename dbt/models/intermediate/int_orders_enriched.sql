{{
  config(
    materialized = 'view',
    schema = 'intermediate'
  )
}}

-- Enriches staged orders with derived business fields.
SELECT
    order_id,
    customer_id,
    order_date,
    toStartOfMonth(order_date)                          AS order_month,
    toDayOfWeek(order_date)                             AS order_day_of_week,
    amount_usd,
    round(amount_usd * 0.92, 2)                         AS amount_eur,
    status,
    status = 'completed'                                AS is_completed,
    _loaded_at
FROM {{ ref('stg_orders') }}
