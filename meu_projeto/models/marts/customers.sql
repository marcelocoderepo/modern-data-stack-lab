select
    customer_id,
    customer_name,
    email,
    created_at,
    date_diff('day', created_at, current_timestamp) as days_since_signup
from {{ ref('stg_customers') }}
