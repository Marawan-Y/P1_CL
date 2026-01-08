-- ============================================================================
-- Paint Shop Production Sequence Optimization - SQL Implementation
-- ============================================================================
-- This SQL script provides data preparation, analysis, and result storage
-- for the paint shop optimization problem. The core MILP optimization is
-- performed in Python, but this script handles all database operations.
--
-- Author: Demand Planning Team
-- Date: January 2026
-- Database: PostgreSQL (compatible with MySQL with minor modifications)
-- ============================================================================

-- ============================================================================
-- SECTION 1: TABLE CREATION
-- ============================================================================

-- Drop existing tables if they exist (for clean re-runs)
DROP TABLE IF EXISTS optimized_vehicle_sequence CASCADE;
DROP TABLE IF EXISTS paint_batch_assignments CASCADE;
DROP TABLE IF EXISTS paint_summary CASCADE;
DROP TABLE IF EXISTS vehicle_staging CASCADE;

-- Create staging table for vehicle data
CREATE TABLE vehicle_staging (
    vin VARCHAR(50) PRIMARY KEY,
    country VARCHAR(10),
    stage VARCHAR(20),
    wheels VARCHAR(10),
    paint VARCHAR(10) NOT NULL,
    autopilot_firmware VARCHAR(10),
    seats VARCHAR(10),
    location VARCHAR(100),
    is_available_for_match INTEGER,
    production_sequence INTEGER NOT NULL,
    planned_ga_in_datetime TIMESTAMP,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index on paint for faster grouping
CREATE INDEX idx_vehicle_paint ON vehicle_staging(paint);
CREATE INDEX idx_vehicle_seq ON vehicle_staging(production_sequence);

-- Create paint summary table
CREATE TABLE paint_summary (
    paint_code VARCHAR(10) PRIMARY KEY,
    vehicle_count INTEGER NOT NULL,
    full_batches INTEGER NOT NULL,
    remainder INTEGER NOT NULL,
    total_batches INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create batch assignments table (from Python optimization)
CREATE TABLE paint_batch_assignments (
    batch_id INTEGER PRIMARY KEY,
    batch_position INTEGER NOT NULL,
    paint_code VARCHAR(10) NOT NULL,
    batch_size INTEGER DEFAULT 20,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create optimized sequence table
CREATE TABLE optimized_vehicle_sequence (
    vin VARCHAR(50) PRIMARY KEY,
    paint VARCHAR(10) NOT NULL,
    batch_id INTEGER NOT NULL,
    production_sequence INTEGER NOT NULL UNIQUE,
    original_sequence INTEGER NOT NULL,
    planned_ga_in_datetime TIMESTAMP,
    optimization_run_id INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (vin) REFERENCES vehicle_staging(vin)
);

CREATE INDEX idx_optimized_seq ON optimized_vehicle_sequence(production_sequence);
CREATE INDEX idx_optimized_paint ON optimized_vehicle_sequence(paint);

-- ============================================================================
-- SECTION 2: DATA LOADING PROCEDURES
-- ============================================================================

-- Function to load data from CSV (adjust path as needed)
-- Note: In practice, use COPY command or bulk insert tools
-- This is a template for the load process

/*
EXAMPLE LOAD COMMAND:
COPY vehicle_staging(
    vin, country, stage, wheels, paint, autopilot_firmware, 
    seats, location, is_available_for_match, production_sequence, 
    planned_ga_in_datetime
)
FROM '/path/to/vehicle_table.csv'
DELIMITER ','
CSV HEADER;
*/

-- ============================================================================
-- SECTION 3: ANALYSIS QUERIES
-- ============================================================================

-- Query 1: Answer to "How many unique paint options are available?"
CREATE OR REPLACE VIEW v_unique_paint_count AS
SELECT 
    COUNT(DISTINCT paint) AS unique_paint_options,
    COUNT(*) AS total_vehicles,
    CURRENT_TIMESTAMP AS analysis_timestamp
FROM vehicle_staging;

-- Query to get unique paint count
SELECT unique_paint_options 
FROM v_unique_paint_count;

-- Query 2: Paint Distribution Analysis
CREATE OR REPLACE VIEW v_paint_distribution AS
SELECT 
    paint AS paint_code,
    COUNT(*) AS vehicle_count,
    COUNT(*) / 20 AS full_batches,
    COUNT(*) % 20 AS remainder,
    CEIL(COUNT(*)::NUMERIC / 20) AS total_batches,
    ROUND(COUNT(*)::NUMERIC / (SELECT COUNT(*) FROM vehicle_staging) * 100, 2) AS percentage
FROM vehicle_staging
GROUP BY paint
ORDER BY vehicle_count DESC;

-- Populate paint summary table
INSERT INTO paint_summary (paint_code, vehicle_count, full_batches, remainder, total_batches)
SELECT 
    paint_code,
    vehicle_count,
    full_batches,
    remainder,
    total_batches
FROM v_paint_distribution
ON CONFLICT (paint_code) DO UPDATE
SET 
    vehicle_count = EXCLUDED.vehicle_count,
    full_batches = EXCLUDED.full_batches,
    remainder = EXCLUDED.remainder,
    total_batches = EXCLUDED.total_batches;

-- Query 3: Current Production Sequence Analysis
CREATE OR REPLACE VIEW v_current_changeovers AS
WITH paint_changes AS (
    SELECT 
        production_sequence,
        paint,
        LAG(paint) OVER (ORDER BY production_sequence) AS prev_paint,
        CASE 
            WHEN LAG(paint) OVER (ORDER BY production_sequence) IS NULL THEN 1
            WHEN LAG(paint) OVER (ORDER BY production_sequence) != paint THEN 1
            ELSE 0
        END AS is_changeover
    FROM vehicle_staging
)
SELECT 
    COUNT(*) FILTER (WHERE is_changeover = 1) AS total_changeovers,
    COUNT(*) AS total_vehicles,
    ROUND(COUNT(*) FILTER (WHERE is_changeover = 1)::NUMERIC / 
          NULLIF(COUNT(DISTINCT paint), 0) * 100, 2) AS changeover_rate_pct
FROM paint_changes;

-- ============================================================================
-- SECTION 4: BATCH CREATION LOGIC (HEURISTIC FALLBACK)
-- ============================================================================
-- This provides a SQL-based heuristic if MILP is not available
-- It's not optimal but provides a reasonable solution

CREATE OR REPLACE FUNCTION create_paint_batches_heuristic()
RETURNS TABLE (
    vin VARCHAR(50),
    paint VARCHAR(10),
    batch_id INTEGER,
    production_sequence INTEGER
) AS $$
DECLARE
    current_batch_id INTEGER := 1;
    current_seq INTEGER := 1;
BEGIN
    -- Create temp table for batch assignments
    CREATE TEMP TABLE IF NOT EXISTS temp_batch_assignments (
        vin VARCHAR(50),
        paint VARCHAR(10),
        batch_id INTEGER,
        production_sequence INTEGER,
        original_sequence INTEGER
    );
    
    TRUNCATE temp_batch_assignments;
    
    -- Assign batches using round-robin approach for level-loading
    WITH paint_order AS (
        SELECT DISTINCT paint, vehicle_count
        FROM v_paint_distribution
        ORDER BY vehicle_count DESC
    ),
    vehicle_with_rn AS (
        SELECT 
            v.vin,
            v.paint,
            v.production_sequence AS original_sequence,
            ROW_NUMBER() OVER (PARTITION BY v.paint ORDER BY v.production_sequence) AS rn_within_paint
        FROM vehicle_staging v
    )
    INSERT INTO temp_batch_assignments
    SELECT 
        vin,
        paint,
        CEIL(rn_within_paint::NUMERIC / 20) AS batch_id_within_paint,
        ROW_NUMBER() OVER (ORDER BY 
            CEIL(rn_within_paint::NUMERIC / 20), 
            paint, 
            original_sequence
        ) AS production_sequence,
        original_sequence
    FROM vehicle_with_rn;
    
    -- Return results
    RETURN QUERY
    SELECT 
        t.vin,
        t.paint,
        t.batch_id,
        t.production_sequence
    FROM temp_batch_assignments t
    ORDER BY t.production_sequence;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SECTION 5: RESULT VALIDATION QUERIES
-- ============================================================================

-- Validate optimized sequence (no duplicates, all VINs present)
CREATE OR REPLACE VIEW v_sequence_validation AS
WITH validation_checks AS (
    SELECT 
        (SELECT COUNT(*) FROM vehicle_staging) AS total_input_vehicles,
        (SELECT COUNT(*) FROM optimized_vehicle_sequence) AS total_output_vehicles,
        (SELECT COUNT(DISTINCT vin) FROM optimized_vehicle_sequence) AS unique_vins,
        (SELECT COUNT(DISTINCT production_sequence) FROM optimized_vehicle_sequence) AS unique_sequences,
        (SELECT MAX(production_sequence) FROM optimized_vehicle_sequence) AS max_sequence,
        (SELECT MIN(production_sequence) FROM optimized_vehicle_sequence) AS min_sequence
)
SELECT 
    *,
    CASE 
        WHEN total_input_vehicles = total_output_vehicles 
         AND unique_vins = total_output_vehicles
         AND unique_sequences = total_output_vehicles
         AND min_sequence = 1
         AND max_sequence = total_output_vehicles
        THEN 'VALID'
        ELSE 'INVALID'
    END AS validation_status
FROM validation_checks;

-- Check for sequence gaps
CREATE OR REPLACE VIEW v_sequence_gaps AS
WITH sequence_numbers AS (
    SELECT generate_series(1, (SELECT MAX(production_sequence) FROM optimized_vehicle_sequence)) AS seq_num
)
SELECT seq_num AS missing_sequence
FROM sequence_numbers
WHERE seq_num NOT IN (SELECT production_sequence FROM optimized_vehicle_sequence)
ORDER BY seq_num;

-- ============================================================================
-- SECTION 6: REPORTING QUERIES
-- ============================================================================

-- Report 1: Optimal VIN Sequence (Answer to Question 2)
CREATE OR REPLACE VIEW v_optimal_vin_sequence AS
SELECT 
    vin,
    paint,
    production_sequence
FROM optimized_vehicle_sequence
ORDER BY production_sequence;

-- Report 2: Changeover Analysis for Optimized Sequence
CREATE OR REPLACE VIEW v_optimized_changeovers AS
WITH paint_changes AS (
    SELECT 
        production_sequence,
        paint,
        batch_id,
        LAG(paint) OVER (ORDER BY production_sequence) AS prev_paint,
        CASE 
            WHEN LAG(paint) OVER (ORDER BY production_sequence) IS NULL THEN 1
            WHEN LAG(paint) OVER (ORDER BY production_sequence) != paint THEN 1
            ELSE 0
        END AS is_changeover
    FROM optimized_vehicle_sequence
)
SELECT 
    COUNT(*) FILTER (WHERE is_changeover = 1) AS total_changeovers,
    COUNT(*) AS total_vehicles,
    COUNT(DISTINCT batch_id) AS total_batches,
    ROUND(COUNT(*) FILTER (WHERE is_changeover = 1)::NUMERIC / 
          NULLIF(COUNT(DISTINCT batch_id), 0) * 100, 2) AS changeover_rate_pct,
    ARRAY_AGG(production_sequence ORDER BY production_sequence) FILTER (WHERE is_changeover = 1) AS changeover_positions
FROM paint_changes;

-- Report 3: Paint Distribution Comparison (Before vs After)
CREATE OR REPLACE VIEW v_paint_distribution_comparison AS
WITH original_dist AS (
    SELECT 
        paint,
        COUNT(*) AS vehicle_count,
        MIN(production_sequence) AS first_appearance,
        MAX(production_sequence) AS last_appearance,
        MAX(production_sequence) - MIN(production_sequence) AS spread
    FROM vehicle_staging
    GROUP BY paint
),
optimized_dist AS (
    SELECT 
        paint,
        COUNT(*) AS vehicle_count,
        MIN(production_sequence) AS first_appearance,
        MAX(production_sequence) AS last_appearance,
        MAX(production_sequence) - MIN(production_sequence) AS spread
    FROM optimized_vehicle_sequence
    GROUP BY paint
)
SELECT 
    o.paint,
    o.vehicle_count,
    orig.spread AS original_spread,
    o.spread AS optimized_spread,
    o.spread - orig.spread AS spread_improvement,
    ROUND((o.spread - orig.spread)::NUMERIC / NULLIF(orig.spread, 0) * 100, 2) AS improvement_pct
FROM optimized_dist o
JOIN original_dist orig ON o.paint = orig.paint
ORDER BY o.vehicle_count DESC;

-- Report 4: Batch Summary
CREATE OR REPLACE VIEW v_batch_summary AS
SELECT 
    batch_id,
    paint,
    COUNT(*) AS vehicles_in_batch,
    MIN(production_sequence) AS start_sequence,
    MAX(production_sequence) AS end_sequence,
    MIN(planned_ga_in_datetime) AS start_time,
    MAX(planned_ga_in_datetime) AS end_time
FROM optimized_vehicle_sequence
GROUP BY batch_id, paint
ORDER BY batch_id;

-- ============================================================================
-- SECTION 7: EXPORT QUERIES
-- ============================================================================

-- Export optimized sequence to CSV
/*
COPY (
    SELECT vin, paint, production_sequence
    FROM v_optimal_vin_sequence
) TO '/path/to/output/optimized_sequence.csv'
DELIMITER ','
CSV HEADER;
*/

-- Export paint summary
/*
COPY (
    SELECT * FROM paint_summary
) TO '/path/to/output/paint_summary.csv'
DELIMITER ','
CSV HEADER;
*/

-- ============================================================================
-- SECTION 8: CLEANUP AND MAINTENANCE
-- ============================================================================

-- Function to clear all optimization results
CREATE OR REPLACE FUNCTION clear_optimization_results()
RETURNS VOID AS $$
BEGIN
    TRUNCATE optimized_vehicle_sequence;
    TRUNCATE paint_batch_assignments;
    TRUNCATE paint_summary;
    RAISE NOTICE 'Optimization results cleared successfully';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SECTION 9: USAGE EXAMPLES AND DOCUMENTATION
-- ============================================================================

/*
=============================================================================
USAGE GUIDE
=============================================================================

1. LOAD DATA:
   - Load vehicle data into vehicle_staging table using COPY command or ETL tool
   - Example: COPY vehicle_staging FROM 'vehicle_table.csv' CSV HEADER;

2. RUN ANALYSIS:
   - Execute: SELECT * FROM v_unique_paint_count;
   - Execute: SELECT * FROM v_paint_distribution;
   - Execute: SELECT * FROM v_current_changeovers;

3. RUN PYTHON OPTIMIZATION:
   - The Python script will read from vehicle_staging
   - It will write results back to optimized_vehicle_sequence

4. VALIDATE RESULTS:
   - Execute: SELECT * FROM v_sequence_validation;
   - Execute: SELECT * FROM v_sequence_gaps;

5. GENERATE REPORTS:
   - Execute: SELECT * FROM v_optimal_vin_sequence;
   - Execute: SELECT * FROM v_optimized_changeovers;
   - Execute: SELECT * FROM v_paint_distribution_comparison;

6. EXPORT RESULTS:
   - Use COPY commands to export views to CSV files

=============================================================================
ANSWER TO QUESTIONS:
=============================================================================

Question 1: How many unique paint options are available?
Answer Query:
    SELECT unique_paint_options FROM v_unique_paint_count;

Question 2: What is the optimal VIN sequence from Paint Shop's perspective?
Answer Query:
    SELECT vin, paint, production_sequence 
    FROM v_optimal_vin_sequence;

=============================================================================
*/

-- Quick answer queries
-- Question 1
SELECT 
    'Question 1: Unique Paint Options' AS question,
    unique_paint_options AS answer
FROM v_unique_paint_count;

-- Question 2 - First 10 rows as sample
SELECT 
    'Question 2: Optimal VIN Sequence (sample)' AS question,
    vin,
    paint,
    production_sequence
FROM v_optimal_vin_sequence
LIMIT 10;
