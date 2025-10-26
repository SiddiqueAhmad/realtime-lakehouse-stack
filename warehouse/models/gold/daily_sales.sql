SELECT
    CAST(order_date AS DATE) AS order_date,
    COUNT(DISTINCT order_number) AS number_of_orders,
    SUM(quantity) AS total_quantity_sold,
    COUNT(DISTINCT customer_name) AS unique_customers
FROM
    {{ ref('enriched_orders') }}
GROUP BY
    CAST(order_date AS DATE)
ORDER BY
    order_date
