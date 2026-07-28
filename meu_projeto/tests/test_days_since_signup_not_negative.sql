-- Test: days_since_signup must never be negative
-- Returns rows that VIOLATE the rule. Test passes when result is empty.

select
    customer_id,
    days_since_signup
from {{ ref('customers') }}
where days_since_signup < 0
