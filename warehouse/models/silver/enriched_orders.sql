
WITH orders AS (

    SELECT
        order_number,
        purchaser AS customer_id,
        product_id,
        quantity,
        order_date
    FROM
        {{ source('inventory', 'debeziumcdc_dbz__inventory_orders') }}

),

customers AS (

    SELECT
        id AS customer_id,
        first_name,
        last_name,
        email
    FROM
        {{ source('inventory', 'debeziumcdc_dbz__inventory_customers') }}

),

products AS (

    SELECT
        id AS product_id,
        name
    FROM
        {{ source('inventory', 'debeziumcdc_dbz__inventory_products') }}

)

SELECT
    o.order_number,
    c.first_name || ' ' || c.last_name AS customer_name,
    p.name AS product_name,
    o.quantity,
    o.order_date
FROM
    orders AS o
LEFT JOIN
    customers AS c
    ON
        o.customer_id = c.customer_id
LEFT JOIN
    products AS p
    ON
        o.product_id = p.product_id
