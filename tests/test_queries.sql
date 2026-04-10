SELECT
    m.machine_name,
    m.machine_type,
    m.stage,
    COUNT(f.fact_id) AS batch_count
FROM fact_batch_production f
JOIN dim_machine m ON f.machine_id = m.machine_id
WHERE f.machine_id IS NOT NULL
GROUP BY m.machine_name, m.machine_type, m.stage
ORDER BY m.stage,
         batch_count DESC,
         m.machine_type;