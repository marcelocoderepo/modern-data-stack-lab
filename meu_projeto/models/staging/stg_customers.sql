select
    id as customer_id,
    name as customer_name,
    lower(email) as email,
    created_at
from {{ source('inventory', 'customers') }}
