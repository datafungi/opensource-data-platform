{{
  config(
    materialized = 'incremental',
    schema = 'marts',
    engine = 'ReplacingMergeTree()',
    order_by = '(order_month, customer_id)',
    unique_key = 'order_id'
  )
}}

-- Daily order fact table — incremental via ReplacingMergeTree.
-- New rows replace existing rows with the same order_id on merge.
SELECT
    order_id,
    customer_id,
    order_date,
    order_month,
    order_day_of_week,
    amount_usd,
    amount_eur,
    status,
    is_completed,
    _loaded_at
FROM {{ ref('int_orders_enriched') }}

{% if is_incremental() %}
WHERE _loaded_at >= (SELECT max(_loaded_at) FROM {{ this }})
{% endif %}
